# Configuração do Firebase

## Arquivo de credenciais (google-services.json)

O arquivo `android/app/google-services.json` contém as credenciais do projeto Firebase e **não é versionado**. Para rodar o app:

1. Acesse o [Console do Firebase](https://console.firebase.google.com/) e abra (ou crie) o projeto.
2. Em **Configurações do projeto → Seus apps**, adicione um app Android com o pacote `com.example.fire_app`.
3. Baixe o `google-services.json` e salve em `android/app/google-services.json`.

O arquivo `android/app/google-services.json.example` mostra a estrutura esperada, sem dados reais.

# Regras do Firebase Realtime Database

## ⚠️ ERRO: Permission Denied

Se você está vendo o erro **"Firebase Database error: Permission denied"**, é porque as regras do Firebase Realtime Database não estão configuradas corretamente.

## 🔧 Como Configurar as Regras do Firebase

### Passo 1: Acessar o Console do Firebase

1. Acesse: https://console.firebase.google.com/
2. Selecione o projeto **FireApp**

### Passo 2: Configurar Realtime Database

1. No menu lateral, clique em **"Realtime Database"**
2. Clique na aba **"Regras"** (Rules)

### Passo 3: Aplicar as Regras

Cole as seguintes regras no editor e clique em **"Publicar"**:

```json
{
  "rules": {
    "usuarios": {
      "$uid": {
        ".read": "$uid === auth.uid",
        ".write": "$uid === auth.uid"
      }
    }
  }
}
```

### O que essas regras fazem?

- **`.read`**: Permite que cada usuário **leia apenas seus próprios dados**
- **`.write`**: Permite que cada usuário **escreva apenas seus próprios dados**
- `$uid === auth.uid`: Garante que o UID na URL coincide com o UID do usuário autenticado

### Passo 4: Verificar

Após publicar as regras:
1. Reinicie o aplicativo
2. Tente acessar **Configurações → Meu Perfil**
3. O erro de permissão deve desaparecer

## 📱 Estrutura dos Dados

Os dados são salvos no seguinte caminho:

```
/usuarios
  /{uid-do-usuario}
    ├── uid: "abc123..."
    ├── email: "usuario@email.com"
    ├── nome: "Nome do Usuário"
    ├── telefone: "62999999999"
    ├── localizacao: "Cidade, Estado"
    ├── receberNotificacoes: true
    ├── receberAlertas: true
    ├── dataCriacao: "2026-03-03T01:00:00.000Z"
    └── dataUltimaAtualizacao: "2026-03-03T01:45:00.000Z"
```

## 🔒 Segurança

Essas regras garantem que:
- ✅ Cada usuário só pode acessar seus próprios dados
- ✅ Ninguém pode ver dados de outros usuários
- ✅ Apenas usuários autenticados podem acessar o banco
- ✅ Alterações só podem ser feitas pelo próprio dono dos dados

## 🚨 IMPORTANTE

**NÃO** use estas regras em produção sem considerar:
- Validação de dados (tipo, tamanho, formato)
- Rate limiting
- Backup automático
- Monitoramento de uso

Para produção, considere usar regras mais restritivas com validação de schema.

---

**Arquivo de regras**: `database.rules.json`
